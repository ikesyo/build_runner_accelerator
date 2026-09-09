import 'package:json_annotation/json_annotation.dart';

part 'model_251.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model251 {
  const Model251({required this.id, required this.value});

  final int id;
  final String value;

  factory Model251.fromJson(Map<String, dynamic> json) =>
      _$Model251FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model251ToJson(this);
}
