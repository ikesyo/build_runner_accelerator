import 'package:json_annotation/json_annotation.dart';

part 'model_238.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model238 {
  const Model238({required this.id, required this.value});

  final int id;
  final String value;

  factory Model238.fromJson(Map<String, dynamic> json) =>
      _$Model238FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model238ToJson(this);
}
