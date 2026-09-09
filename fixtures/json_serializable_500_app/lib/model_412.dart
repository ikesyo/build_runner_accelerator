import 'package:json_annotation/json_annotation.dart';

part 'model_412.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model412 {
  const Model412({required this.id, required this.value});

  final int id;
  final String value;

  factory Model412.fromJson(Map<String, dynamic> json) =>
      _$Model412FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model412ToJson(this);
}
