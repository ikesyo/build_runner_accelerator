import 'package:json_annotation/json_annotation.dart';

part 'model_215.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model215 {
  const Model215({required this.id, required this.value});

  final int id;
  final String value;

  factory Model215.fromJson(Map<String, dynamic> json) =>
      _$Model215FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model215ToJson(this);
}
