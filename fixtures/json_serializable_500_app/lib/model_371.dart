import 'package:json_annotation/json_annotation.dart';

part 'model_371.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model371 {
  const Model371({required this.id, required this.value});

  final int id;
  final String value;

  factory Model371.fromJson(Map<String, dynamic> json) =>
      _$Model371FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model371ToJson(this);
}
