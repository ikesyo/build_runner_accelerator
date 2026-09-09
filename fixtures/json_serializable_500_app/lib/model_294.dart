import 'package:json_annotation/json_annotation.dart';

part 'model_294.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model294 {
  const Model294({required this.id, required this.value});

  final int id;
  final String value;

  factory Model294.fromJson(Map<String, dynamic> json) =>
      _$Model294FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model294ToJson(this);
}
