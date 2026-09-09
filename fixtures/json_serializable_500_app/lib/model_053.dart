import 'package:json_annotation/json_annotation.dart';

part 'model_053.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model053 {
  const Model053({required this.id, required this.value});

  final int id;
  final String value;

  factory Model053.fromJson(Map<String, dynamic> json) =>
      _$Model053FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model053ToJson(this);
}
