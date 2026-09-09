import 'package:json_annotation/json_annotation.dart';

part 'model_067.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model067 {
  const Model067({required this.id, required this.value});

  final int id;
  final String value;

  factory Model067.fromJson(Map<String, dynamic> json) =>
      _$Model067FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model067ToJson(this);
}
