import 'package:json_annotation/json_annotation.dart';

part 'model_441.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model441 {
  const Model441({required this.id, required this.value});

  final int id;
  final String value;

  factory Model441.fromJson(Map<String, dynamic> json) =>
      _$Model441FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model441ToJson(this);
}
