import 'package:json_annotation/json_annotation.dart';

part 'model_146.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model146 {
  const Model146({required this.id, required this.value});

  final int id;
  final String value;

  factory Model146.fromJson(Map<String, dynamic> json) =>
      _$Model146FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model146ToJson(this);
}
